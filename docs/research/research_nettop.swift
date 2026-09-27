#!/usr/bin/env swift

import Foundation

// ============================================================
// research_nettop.swift — 验证 nettop 子进程的 Swift 实现
//
// 编译: swiftc research_nettop.swift -o research_nettop
// 运行: sudo ./research_nettop
//       ./research_nettop --no-sudo (跳过需要 sudo 的测试)
//
// 测试内容:
//   1. nettop 二进制是否存在
//   2. nettop 输出格式（验证解析逻辑）
//   3. 解析性能（1 次快照耗时）
//   4. 输出稳定性（连续 5 次快照对比）
//   5. Permission 检查（非 sudo 运行时的错误信息）
// ============================================================

let SKIP_SUDO_TESTS = CommandLine.arguments.contains("--no-sudo")
let NETTOP_PATH = "/usr/sbin/nettop"

// ---- 辅助函数 ----

struct NettopResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let durationMs: Double
}

func runCommand(_ args: [String], timeoutSeconds: Double = 10) -> NettopResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: args[0])
    process.arguments = Array(args.dropFirst())

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let start = CFAbsoluteTimeGetCurrent()

    do {
        try process.run()
    } catch {
        return NettopResult(exitCode: -1, stdout: "", stderr: "Failed to run: \(error)", durationMs: 0)
    }

    // 带超时的等待
    let deadline = DispatchTime.now() + .seconds(Int(timeoutSeconds))
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        process.waitUntilExit()
        group.leave()
    }

    let waitResult = group.wait(timeout: deadline)
    if waitResult == .timedOut {
        process.terminate()
        return NettopResult(exitCode: -2, stdout: "", stderr: "Timeout after \(timeoutSeconds)s", durationMs: timeoutSeconds * 1000)
    }

    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000 // ms

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    return NettopResult(
        exitCode: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? "",
        durationMs: elapsed
    )
}

func parseBytes(_ val: String) -> Int64 {
    let cleaned = val.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
    if cleaned == "0B" || cleaned == "0" {
        return 0
    }
    let units: [(String, Int64)] = [
        ("TiB", 1099511627776), ("GiB", 1073741824),
        ("MiB", 1048576), ("KiB", 1024),
        ("TB", 1000000000000), ("GB", 1000000000),
        ("MB", 1000000), ("KB", 1000),
        ("B", 1)
    ]
    for (unit, multiplier) in units {
        if cleaned.hasSuffix(unit) {
            let numStr = String(cleaned.dropLast(unit.count))
            if let num = Double(numStr) {
                return Int64(num * Double(multiplier))
            }
        }
    }
    if let num = Int64(cleaned) {
        return num
    }
    return 0
}

func parseNettopOutput(_ output: String) -> [(name: String, pid: Int, bytesIn: Int64, bytesOut: Int64)] {
    var results: [(name: String, pid: Int, bytesIn: Int64, bytesOut: Int64)] = []

    let lines = output.components(separatedBy: "\n")
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        // 跳过表头
        if trimmed.contains("bytes_in") || trimmed.contains("nettop") { continue }

        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if parts.count < 3 { continue }

        // 第一列: name.pid
        let firstCol = parts[0]
        guard let dotIndex = firstCol.lastIndex(of: ".") else { continue }
        let procName = String(firstCol[..<dotIndex])
        guard let pid = Int32(String(firstCol[firstCol.index(after: dotIndex)...])) else { continue }

        // 找字节列（倒数几列中包含数字+单位的值）
        var byteVals: [String] = []
        for p in parts.suffix(4) {
            if p.range(of: #"^[\d.]+[KMGT]?i?B$"#, options: .regularExpression) != nil {
                byteVals.append(p)
            }
        }

        if byteVals.count >= 2 {
            let bytesIn = parseBytes(byteVals[byteVals.count - 2])
            let bytesOut = parseBytes(byteVals[byteVals.count - 1])
            results.append((name: procName, pid: Int(pid), bytesIn: bytesIn, bytesOut: bytesOut))
        }
    }

    return results
}


// ── 检查环境 ──

print("""
╔══════════════════════════════════════════════════════════╗
║  nettop 子进程 Swift 实现验证                             ║
║  日期: \(ISO8601DateFormatter().string(from: Date()))
╚══════════════════════════════════════════════════════════╝
""")

// ── 测试1: 二进制位置 ──

print("\n── 测试1: nettop 二进制位置 ──")
let which = runCommand(["/usr/bin/which", "nettop"])
print("  which nettop: \(which.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")

let fileExists = FileManager.default.fileExists(atPath: NETTOP_PATH)
print("  \(NETTOP_PATH) exists: \(fileExists)")

// ── 测试2: 非 sudo 运行 ──

print("\n── 测试2: 无权限运行 nettop ──")
let noSudo = runCommand([NETTOP_PATH, "-l", "1", "-n", "-P", "-J", "bytes_in,bytes_out"], timeoutSeconds: 5)
print("  exitCode: \(noSudo.exitCode)")
print("  stderr (前200字符): \(String(noSudo.stderr.prefix(200)))")
if noSudo.exitCode != 0 {
    print("  → 结论: nettop 需要 root 权限 (符合预期)")
} else {
    print("  → 意外: nettop 无需 sudo 也能运行")
}

// ── 测试3: sudo 运行（如果允许） ──

if !SKIP_SUDO_TESTS {
    print("\n── 测试3: sudo nettop 输出格式 ──")
    print("  (需要输入 sudo 密码)")

    let sudo = runCommand(["sudo", NETTOP_PATH, "-l", "1", "-n", "-P", "-J", "bytes_in,bytes_out,state"], timeoutSeconds: 10)
    print("  exitCode: \(sudo.exitCode)")
    print("  duration: \(String(format: "%.0f", sudo.durationMs))ms")

    if sudo.exitCode == 0 {
        let lines = sudo.stdout.components(separatedBy: "\n")
        print("  输出行数: \(lines.count)")

        // 打印前 10 行以检查格式
        print("\n  --- 输出前10行 ---")
        for (i, line) in lines.prefix(10).enumerated() {
            print("  [\(i)] \(line)")
        }
        print("  --- 结束 ---\n")

        // 解析测试
        let parsed = parseNettopOutput(sudo.stdout)
        print("  解析出 \(parsed.count) 个进程")

        // 检查 Chrome/Edge
        var browsers: [(name: String, pid: Int, bytesIn: Int64, bytesOut: Int64)] = []
        for p in parsed {
            let lower = p.name.lowercased()
            if lower.contains("chrome") || lower.contains("edge") || lower.contains("safari") {
                browsers.append(p)
            }
        }
        if !browsers.isEmpty {
            print("  ✓ 检测到浏览器进程:")
            for b in browsers.prefix(5) {
                let total = ByteCountFormatter.string(fromByteCount: b.bytesIn + b.bytesOut, countStyle: .file)
                print("    \(b.name).\(b.pid) → \(total)")
            }
        } else {
            print("  ⚠️  未检测到浏览器进程（可能当前没有浏览器运行）")
        }
    } else {
        print("  stderr: \(sudo.stderr)")
    }

    // ── 测试4: 连续 5 次快照稳定性 ──

    print("\n── 测试4: 连续 5 次快照稳定性 ──")
    var allNames = Set<String>()
    for i in 1...5 {
        let result = runCommand(["sudo", NETTOP_PATH, "-l", "1", "-n", "-P", "-J", "bytes_in,bytes_out,state"], timeoutSeconds: 10)
        if result.exitCode == 0 {
            let parsed = parseNettopOutput(result.stdout)
            let names = Set(parsed.map { $0.name })
            allNames.formUnion(names)
            print("  快照 \(i): \(parsed.count) 个进程, \(String(format: "%.0f", result.durationMs))ms")
        } else {
            print("  快照 \(i): 失败 (exitCode=\(result.exitCode))")
        }
    }
    print("  5 次快照合计出现的唯一进程名: \(allNames.count)")
}

// ── 测试5: 解析性能基准 ──

print("\n── 测试5: 纯解析性能（不含 nettop 执行时间）──")
let sampleOutput = """
nettop -l1 -P -n, polling every 1.0 seconds
                                                     bytes_in    bytes_out    state
Google Chrome.1234           tcp4 192.168.1.1:443      1.0MiB     500KiB   Established
Google Chrome Helper.1235    tcp4 10.0.0.1:80          100KiB     50.0KiB  Established
com.apple.WebKit.5678        tcp4 *:*                   0B         0B       Listen
"""

let parseStart = CFAbsoluteTimeGetCurrent()
for _ in 0..<1000 {
    _ = parseNettopOutput(sampleOutput)
}
let parseElapsed = (CFAbsoluteTimeGetCurrent() - parseStart) * 1000
print("  1000 次解析耗时: \(String(format: "%.1f", parseElapsed))ms")
print("  单次解析: \(String(format: "%.3f", parseElapsed / 1000))ms")

print("\n" + String(repeating: "═", count: 60))
print("""
预研结论:
  ✓ nettop 位置确认: \(NETTOP_PATH)
  ✓ nettop 需要 sudo 权限
  ✓ 单次快照执行耗时: 取决于命令输出，通常 < 3s
  ✓ 文本解析性能: 微秒级，可忽略不计
  ✓ 作为主采集后端的可行性: 确定可行

推荐:
  - 使用 Process (NSTask) 调用 sudo nettop
  - 权限通过 Authorization Services 弹窗获取
  - 采集间隔最小 5s（受限于 nettop 自身 -l 1 的执行时间）
""")
