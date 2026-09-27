#!/usr/bin/env swift

import Foundation

// ============================================================
// research_privilege.swift — 验证提权弹窗方案
//
// 编译: swiftc research_privilege.swift -o research_privilege
// 运行: ./research_privilege
//
// 测试内容:
//   1. 检查当前用户是否有 sudo 权限
//   2. 测试 AuthorizationCreate + AuthorizationExecuteWithPrivileges
//   3. 测试 AppleScript "do shell script with administrator privileges"
//   4. 交互流程验证: 弹窗 → 输密码 → 执行 nettop → 释放权限
//   5. 错误处理（密码错误、取消、超时等）
// ============================================================

import Security

// ---- 辅助函数 ----

func runCommand(_ args: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: args[0])
    process.arguments = Array(args.dropFirst())

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (-1, "", "Failed: \(error)")
    }

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (process.terminationStatus, stdout, stderr)
}

print("""
╔══════════════════════════════════════════════════════════╗
║  提权弹窗方案验证                                        ║
║  日期: \(ISO8601DateFormatter().string(from: Date()))
╚══════════════════════════════════════════════════════════╝
""")

// ── 测试1: 用户 sudo 能力检查 ──

print("\n── 测试1: 当前用户 sudo 能力 ──")
let whoami = runCommand(["/usr/bin/whoami"])
let currentUser = whoami.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
print("  当前用户: \(currentUser)")

// 检查是否在 admin 组
let groups = runCommand(["/usr/bin/groups"])
print("  用户组: \(groups.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")

let isAdmin = groups.stdout.contains("admin")
print("  是否 admin: \(isAdmin)")

// 检查 sudoers
let sudoL = runCommand(["/usr/bin/sudo", "-l"])
if sudoL.exitCode == 0 {
    print("  sudo -l: 成功（用户有 sudo 权限）")
} else {
    print("  sudo -l: 失败（可能需要密码或用户不在 sudoers）")
}

// ── 测试2: Authorization Services API 概述 ──

print("""

── 测试2: macOS 提权方式对比 ──

方式 A: AuthorizationCreate + AuthorizationExecuteWithPrivileges
  - macOS 原生 Security.framework API
  - 弹出系统标准授权对话框
  - 可以执行单个命令并获取输出
  - ⚠️ 已被 Apple 标记为 deprecated (macOS 10.7+)
  - 但至今仍可用（macOS 14/15 实测可行）

方式 B: SMJobBless + PrivilegedHelperTool
  - Apple 推荐的现代做法
  - 需要：独立的 Helper 可执行文件 + 代码签名 + plist
  - 安装：一次性授权（不是每次弹窗）
  - 复杂度高，需维护两个 target

方式 C: AppleScript "do shell script with administrator privileges"
  - 通过 NSAppleScript 执行
  - 弹出密码对话框
  - 简单但有安全隐患（脚本注入风险）
  - 可以获取返回值

方式 D: Process 直接调 sudo（带 -S 从 stdin 传入密码）
  - 需要用户以其他方式提供密码
  - 不够优雅，不适合 GUI 应用

推荐方案: 方式 A（简单直接，够用）或方式 C（作为备选）

详细分析见 research.md
""")

// ── 测试3: Authorization Services 实战 ──

print("── 测试3: AuthorizationExecuteWithPrivileges 实战 ──")
print("  即将弹出系统授权对话框...")
print("  请在对话框中输入管理员密码\n")

// 创建授权引用
var authRef: AuthorizationRef?
let authStatus = AuthorizationCreate(nil, nil, [], &authRef)

if authStatus != errAuthorizationSuccess {
    print("  AuthorizationCreate 失败: \(authStatus)")
    if authStatus == errAuthorizationDenied {
        print("  → 用户拒绝了授权或应用无签名")
    }
} else {
    print("  AuthorizationCreate 成功")

    // 定义要执行的命令
    let cmd = "/usr/sbin/nettop"
    var args: [UnsafeMutablePointer<CChar>?] = [
        strdup("-l"), strdup("1"),
        strdup("-n"), strdup("-P"),
        strdup("-J"), strdup("bytes_in,bytes_out,state"),
        nil
    ]
    defer {
        for i in 0..<(args.count - 1) {
            free(args[i])
        }
    }

    // 执行
    var fileRef: FILE?
    let execStatus = AuthorizationExecuteWithPrivileges(
        authRef!,
        cmd,
        [],
        &args,
        &fileRef
    )

    print("  AuthorizationExecuteWithPrivileges 状态: \(execStatus)")

    if execStatus == errAuthorizationSuccess, let file = fileRef {
        print("  → 授权成功! nettop 正在运行...")
        var output = ""
        let buffer = [CChar](repeating: 0, count: 4096)
        while fgets(UnsafeMutablePointer(mutating: buffer), Int32(buffer.count), file) != nil {
            output += String(cString: buffer)
        }
        fclose(file)

        // 检查输出
        let lines = output.components(separatedBy: "\n")
        print("  输出共 \(lines.count) 行")
        if lines.count > 2 {
            print("  nettop 输出示例:")
            for line in lines.prefix(5) where !line.isEmpty {
                print("    \(String(line.prefix(100)))")
            }
        } else {
            print("  ⚠️ 输出为空或格式异常")
        }
    } else if execStatus == errAuthorizationCanceled {
        print("  → 用户取消了授权")
    } else if execStatus == errAuthorizationDenied {
        print("  → 授权被拒绝")
    } else if execStatus == errAuthBadUsername {
        print("  → 错误的用户名")
    } else {
        print("  → 授权执行失败 (错误码: \(execStatus))")
    }

    // 释放授权
    AuthorizationFree(authRef!, [])
}

// ── 测试4: AppleScript 备选方案 ──

print("\n── 测试4: AppleScript 'do shell script with administrator privileges' ──")
let scriptSource = """
do shell script "nettop -l 1 -n -P -J bytes_in,bytes_out,state" with administrator privileges
"""

if let script = NSAppleScript(source: scriptSource) {
    var errorDict: NSDictionary?
    let result = script.executeAndReturnError(&errorDict)

    if let error = errorDict {
        let errorNum = error[NSAppleScript.errorNumber] as? Int ?? -1
        let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "unknown"
        print("  AppleScript 错误: \(errorNum) - \(errorMsg)")
        if errorNum == -128 {
            print("  → 用户取消了密码对话框（符合预期）")
        }
    } else {
        let output = result.stringValue ?? ""
        let lines = output.components(separatedBy: "\n")
        print("  AppleScript 成功!")
        print("  输出 \(lines.count) 行")
        if lines.count > 2 {
            print("  nettop 输出示例:")
            for line in lines.prefix(3) {
                print("    \(String(line.prefix(100)))")
            }
        }
    }
} else {
    print("  NSAppleScript 创建失败")
}

// ── 总结 ──

print("""

════════════════════════════════════════════════════════════
预研结论:

  推荐方案: AppleScript "do shell script with administrator privileges"
  理由:
    - AuthorizationExecuteWithPrivileges 已被 Apple 标记 deprecated
      且 API 非常 C-style（char** 参数处理繁琐）
    - AppleScript 更 Swift-friendly，可以直接嵌入代码
    - 弹窗 UI 简洁一致（系统标准密码对话框）
    - 每次调用都会弹窗（安全性更好，不给静默提权机会）

  实现要点:
    - 使用 NSAppleScript 执行
    - 权限仅对单次 nettop 调用有效
    - 不需要持久化存储密码
    - 错误处理: -128 = 用户取消, 其他 = 权限错误

  注意:
    - 如果用户频繁取消授权，使用体验会很差
    - 建议: 授权一次后，将 sudo timestamp 延长
      (执行 "sudo -v" 通过 AppleScript 延长 session)
    - 或者在采集器生命期内保持一个持久的授权 session
════════════════════════════════════════════════════════════
""")
