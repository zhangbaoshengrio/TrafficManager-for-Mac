#!/usr/bin/env swift

import Foundation

// ============================================================
// research_libproc.swift — 验证 libproc API 能否获取进程级网络字节数
//
// 编译: swiftc research_libproc.swift -o research_libproc
// 运行: ./research_libproc [PID]
//       ./research_libproc          → 测试所有 Chrome/Edge 进程
//       ./research_libproc 1234     → 测试指定 PID
//
// 测试的 API:
//   1. proc_pidinfo(pid, PROC_PIDTASKALLINFO, ...) — 综合任务信息
//   2. proc_pid_rusage(pid, RUSAGE_INFO_V5, ...)   — 资源使用统计
//   3. proc_pidinfo(pid, PROC_PIDLISTFDS, ...)     — 文件描述符列表
//   4. proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, ...) — socket 信息
// ============================================================

// ---- Darwin/libproc 类型定义 ----

// proc_pidinfo flavors
let PROC_PIDLISTFDS: Int32 = 1
let PROC_PIDTASKALLINFO: Int32 = 2
let PROC_PIDTBSDINFO: Int32 = 3
let PROC_PIDTASKINFO: Int32 = 4
let PROC_PIDRNODEINFO: Int32 = 9
let PROC_PIDLISTFILEPORTS: Int32 = 13

// proc_pidfdinfo flavors
let PROC_PIDFDVNODEPATHINFO: Int32 = 9
let PROC_PIDFDSOCKETINFO: Int32 = 3

// proc_pid_rusage flavors
let RUSAGE_INFO_V0: Int32 = 0
let RUSAGE_INFO_V1: Int32 = 1
let RUSAGE_INFO_V2: Int32 = 2
let RUSAGE_INFO_V3: Int32 = 3
let RUSAGE_INFO_V4: Int32 = 4
let RUSAGE_INFO_V5: Int32 = 5

// proc_pidinfo
@_silgen_name("proc_pidinfo")
func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer, _ buffersize: Int32) -> Int32

// proc_pidfdinfo
@_silgen_name("proc_pidfdinfo")
func proc_pidfdinfo(_ pid: Int32, _ fd: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: Int32) -> Int32

// proc_pid_rusage
@_silgen_name("proc_pid_rusage")
func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

// proc_name
@_silgen_name("proc_name")
func proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

// proc_listallpids
@_silgen_name("proc_listallpids")
func proc_listallpids(_ buffer: UnsafeMutableRawPointer, _ buffersize: Int32) -> Int32

// proc_pidpath
@_silgen_name("proc_pidpath")
func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32


// ---- 数据结构 ----

/// proc_taskallinfo — 进程综合信息（含 taskinfo + bsdinfo）
struct proc_taskallinfo {
    var pbsd: proc_bsdinfo
    var ptinfo: proc_taskinfo
}
// 手动算 sizeof，避免 Mirror
// proc_bsdinfo 约为 136 字节, proc_taskinfo 约为 88 字节 → 总共 224
let SIZE_TASKALLINFO = 224

/// proc_taskinfo — 任务级统计
struct proc_taskinfo {
    var pti_virtual_size: UInt64    // 8
    var pti_resident_size: UInt64   // 8
    var pti_total_user: UInt64      // 8  ← CPU 用户态时间 (μs)
    var pti_total_system: UInt64    // 8  ← CPU 内核态时间 (μs)
    var pti_threads_user: UInt64    // 8
    var pti_threads_system: UInt64  // 8
    var pti_policy: Int32           // 4
    var pti_faults: Int32           // 4
    var pti_pageins: Int32          // 4
    var pti_cow_faults: Int32       // 4
    var pti_messages_sent: Int32    // 4
    var pti_messages_received: Int32 // 4
    var pti_syscalls_mach: Int32   // 4
    var pti_syscalls_unix: Int32   // 4
    var pti_csw: Int32             // 4
    var pti_threadnum: Int32       // 4
    var pti_numrunning: Int32      // 4
    var pti_priority: Int32        // 4
}
let SIZE_TASKINFO = 96

/// proc_bsdinfo
struct proc_bsdinfo {
    var pbi_flags: UInt32          // 4
    var pbi_status: UInt32         // 4
    var pbi_xstatus: UInt32        // 4
    var pbi_pid: Int32             // 4
    var pbi_ppid: Int32            // 4
    var pbi_uid: UInt32            // 4
    var pbi_gid: UInt32            // 4
    var pbi_ruid: UInt32           // 4
    var pbi_rgid: UInt32           // 4
    var pbi_svuid: UInt32          // 4
    var pbi_svgid: UInt32          // 4
    var _rfu1: UInt32              // 4 (padding)
    // ... more fields (name, comm, etc.)
    // 但前 48 字节足够我们读 pbi_pid 验证
}
let SIZE_BSDINFO = 136

/// rusage_info_v5 — 资源使用统计 v5（macOS 10.14+）
struct rusage_info_v5 {
    var ri_uuid: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                   UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    var ri_user_time: UInt64
    var ri_system_time: UInt64
    var ri_pkg_idle_wkups: UInt64
    var ri_interrupt_wkups: UInt64
    var ri_pageins: UInt64
    var ri_wired_size: UInt64
    var ri_resident_size: UInt64
    var ri_phys_footprint: UInt64
    var ri_proc_start_abstime: UInt64
    var ri_proc_exit_abstime: UInt64
    var ri_child_user_time: UInt64
    var ri_child_system_time: UInt64
    var ri_child_pkg_idle_wkups: UInt64
    var ri_child_interrupt_wkups: UInt64
    var ri_child_pageins: UInt64
    var ri_child_elapsed_abstime: UInt64
    var ri_diskio_bytesread: UInt64
    var ri_diskio_byteswritten: UInt64
    var ri_cpu_time_qos_default: UInt64
    var ri_cpu_time_qos_maintenance: UInt64
    var ri_cpu_time_qos_background: UInt64
    var ri_cpu_time_qos_utility: UInt64
    var ri_cpu_time_qos_legacy: UInt64
    var ri_cpu_time_qos_user_initiated: UInt64
    var ri_cpu_time_qos_user_interactive: UInt64
    var ri_billed_system_time: UInt64
    var ri_serviced_system_time: UInt64
    var ri_logical_writes: UInt64
    var ri_lifetime_max_phys_footprint: UInt64
    var ri_instructions: UInt64
    var ri_cycles: UInt64
    var ri_bw_energy: UInt64
    var ri_bw_pre_energy: UInt64
    var ri_bw_cpu_time_qos_default: UInt64
    var ri_bw_cpu_time_qos_maintenance: UInt64
    var ri_bw_cpu_time_qos_background: UInt64
    var ri_bw_cpu_time_qos_utility: UInt64
    var ri_bw_cpu_time_qos_legacy: UInt64
    var ri_bw_cpu_time_qos_user_initiated: UInt64
    var ri_bw_cpu_time_qos_user_interactive: UInt64
    var ri_bw_energy_nj: UInt64
    var ri_bw_pre_energy_nj: UInt64
    var ri_bw_energy_nj_per_cycle: UInt64
    var ri_gpu_energy_nj: UInt64
    var ri_gpu_energy_nj_per_cycle: UInt64
    var ri_avg_latency_us: UInt64
    var ri_io_energy_nj: UInt64
    // ri_network_read_bytes 和 ri_network_write_bytes 不存在于标准结构体中
    // 这是本次预研的核心测试点
}
let SIZE_RUSAGE_V5 = 400 // 足够大的缓冲区

/// socket fd info
struct socket_fdinfo {
    var pfi: proc_fileinfo
    var psi: socket_info
}
let SIZE_SOCKET_FDINFO = 328

struct proc_fileinfo {
    var fi_openflags: UInt32
    var fi_status: UInt32
    var fi_offset: Int64
    var fi_type: Int32
    var fi_guardflags: UInt32
}
// padding to 24 bytes

// 实际结构体对齐可能不同，我们使用大缓冲区 + 手动偏移


// ---- 辅助函数 ----

func getProcessName(pid: Int32) -> String {
    var name = [UInt8](repeating: 0, count: 256)
    let ret = proc_name(pid, &name, 256)
    if ret > 0 {
        return String(cString: name)
    }
    return "unknown"
}

func getProcessPath(pid: Int32) -> String {
    var path = [UInt8](repeating: 0, count: 4096)
    let ret = proc_pidpath(pid, &path, 4096)
    if ret > 0 {
        return String(cString: path)
    }
    return "unknown"
}

func getUInt64(at offset: Int, in buffer: UnsafeMutableRawPointer) -> UInt64 {
    return buffer.load(fromByteOffset: offset, as: UInt64.self)
}

func getUInt32(at offset: Int, in buffer: UnsafeMutableRawPointer) -> UInt32 {
    return buffer.load(fromByteOffset: offset, as: UInt32.self)
}

func getInt32(at offset: Int, in buffer: UnsafeMutableRawPointer) -> Int32 {
    return buffer.load(fromByteOffset: offset, as: Int32.self)
}

func findTargetPids(givenPid: Int32? = nil) -> [Int32] {
    if let pid = givenPid {
        return [pid]
    }

    // 列出所有 PID
    var pids = [Int32](repeating: 0, count: 4096)
    let count = proc_listallpids(&pids, Int32(MemoryLayout<Int32>.stride * pids.count))
    let numPids = Int(count) / MemoryLayout<Int32>.stride

    // 找到浏览器、VS Code 等典型网络应用
    var targetPids = [Int32]()
    for i in 0..<min(numPids, pids.count) {
        let pid = pids[i]
        if pid <= 0 { continue }
        let name = getProcessName(pid: pid)
        let lower = name.lowercased()
        if lower.contains("chrome") || lower.contains("edge") ||
           lower.contains("safari") || lower.contains("firefox") ||
           lower.contains("code") || lower.contains("wechat") ||
           lower.contains("telegram") || lower.contains("slack") {
            targetPids.append(pid)
            if targetPids.count >= 5 { break }
        }
    }
    if targetPids.isEmpty, numPids > 0 {
        // fallback: 取前 3 个有效 PID
        for i in 0..<min(numPids, 100) where pids[i] > 0 {
            targetPids.append(pids[i])
            if targetPids.count >= 3 { break }
        }
    }
    return targetPids
}


// ---- 测试函数 ----

func testProcPidInfo(pid: Int32) {
    print("\n── test: proc_pidinfo(PROC_PIDTASKALLINFO) for PID \(pid) ──")
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: SIZE_TASKALLINFO, alignment: 8)
    defer { buffer.deallocate() }
    memset(buffer, 0, SIZE_TASKALLINFO)

    let ret = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, buffer, Int32(SIZE_TASKALLINFO))
    print("  ret = \(ret) (expected ~\(SIZE_TASKALLINFO))")

    if ret > 0 {
        // taskinfo 从偏移 SIZE_BSDINFO (136) 开始
        let tiOffset = SIZE_BSDINFO
        print("  pti_virtual_size:  \(getUInt64(at: tiOffset + 0, in: buffer))")
        print("  pti_resident_size: \(getUInt64(at: tiOffset + 8, in: buffer))")
        print("  pti_total_user:    \(getUInt64(at: tiOffset + 16, in: buffer)) μs (CPU)")
        print("  pti_total_system:  \(getUInt64(at: tiOffset + 24, in: buffer)) μs (CPU)")
        print("  pti_syscalls_mach: \(getInt32(at: tiOffset + 60, in: buffer))")
        print("  pti_syscalls_unix: \(getInt32(at: tiOffset + 64, in: buffer))")
        print("  → 结论: PROC_PIDTASKALLINFO 没有网络字节字段 (只有 CPU 时间)")
    } else {
        print("  → 调用失败")
    }
}

func testProcPidRusage(pid: Int32) {
    print("\n── test: proc_pid_rusage(RUSAGE_INFO_V5) for PID \(pid) ──")

    for version: Int32 in [RUSAGE_INFO_V2, RUSAGE_INFO_V3, RUSAGE_INFO_V4, RUSAGE_INFO_V5] {
        let bufSize = 512
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buffer.deallocate() }
        memset(buffer, 0, bufSize)

        let ret = proc_pid_rusage(pid, version, buffer)
        let label = ["V0", "V1", "V2", "V3", "V4", "V5"][Int(version)]
        print("  RUSAGE_INFO_\(label): ret=\(ret)")

        if ret == 0 {
            // 打印前 20 个 UInt64 字段
            let count = bufSize / 8
            var fields = [String]()
            for i in 0..<min(count, 20) {
                let val = getUInt64(at: i * 8, in: buffer)
                fields.append("f\(i)=\(val)")
            }
            print("    前20个UInt64: \(fields.joined(separator: ", "))")

            // 特别注意: 检查是否有非零字段看起来像网络字节数
            // ri_diskio_bytesread  = offset 17*8 = 136
            // ri_diskio_byteswritten = offset 18*8 = 144
            let diskRead  = getUInt64(at: 17 * 8, in: buffer)
            let diskWrite = getUInt64(at: 18 * 8, in: buffer)
            print("    ri_diskio_bytesread:  \(diskRead)")
            print("    ri_diskio_byteswritten: \(diskWrite)")
            print("    → 注意: 这是磁盘 IO，不是网络 IO")
        }
    }
    print("  → 结论: rusage 只有磁盘 IO 和 CPU 统计，无网络字节字段")
}

func testProcPidListFds(pid: Int32) {
    print("\n── test: proc_pidinfo(PROC_PIDLISTFDS) for PID \(pid) ──")

    // 第一步：获取 fd 列表
    let bufSize = 1024 * 1024 // 1MB buffer for large fd lists
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
    defer { buffer.deallocate() }
    memset(buffer, 0, bufSize)

    let ret = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer, Int32(bufSize))
    if ret <= 0 {
        print("  PROC_PIDLISTFDS failed: ret=\(ret)")
        return
    }

    // 返回的是 proc_fdinfo 数组，每个约 64 字节
    let fdInfoSize = ret
    print("  PROC_PIDLISTFDS returned \(fdInfoSize) bytes")

    // 尝试遍历 fd 条目找到 socket
    // proc_fdinfo: proc_fd(4) + fd(4) = 8 bytes header, then type-specific
    // 实际上更复杂，我们只计数并尝试几个
    let estimatedEntries = Int(fdInfoSize) / 64
    print("  Estimated fd entries: \(estimatedEntries)")

    // 对前几个 fd，尝试 PROC_PIDFDSOCKETINFO
    var socketCount = 0
    for i in 0..<min(estimatedEntries, 50) {
        let offset = i * 64
        let fd = getInt32(at: offset + 0, in: buffer)
        if fd <= 2 { continue } // skip stdin/stdout/stderr

        // 检查是否为 socket (proc_fdtype = 2 可能是 socket)
        let fdType = getUInt32(at: offset + 4, in: buffer)

        if fdType == 2 { // PROX_FDTYPE_SOCKET
            socketCount += 1

            // 获取 socket 详细信息
            var sockBuf = [UInt8](repeating: 0, count: SIZE_SOCKET_FDINFO)
            let sockRet = sockBuf.withUnsafeMutableBytes { ptr in
                proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, ptr.baseAddress!, Int32(SIZE_SOCKET_FDINFO))
            }

            if socketCount <= 3 {
                if sockRet > 0 {
                    // 解析 socket_info 中的统计信息
                    // socket_info 包含 soi_statistics (在偏移约 152 处)
                    // 不精确但可以探测
                    print("    fd \(fd) (type=\(fdType)): socket_info size=\(sockRet)")

                    // 打印整个 buffer 的前几个字节以理解结构
                    if socketCount == 1 {
                        var hex = ""
                        for j in 0..<min(sockRet, 80) {
                            hex += String(format: "%02x ", sockBuf[Int(j)])
                        }
                        print("    原始数据(前80字节): \(hex)")
                    }
                }
            }
        }
    }
    print("  Socket fds found: \(socketCount)")
    print("  → 结论: PROC_PIDLISTFDS + PROC_PIDFDSOCKETINFO 可以枚举 socket，")
    print("           但 socket_info 结构中的 soi_statistics 是否含字节数需要")
    print("           进一步查阅 XNU 源码确认 (so_statistics 结构体)")
}


// MARK: - 推荐方案预研：NSTask 调用 nettop

func testNettopAvailability() {
    print("\n── 对比: nettop 是否可以获取进程网络字节 ──")
    print("  (此测试需要手动运行 'sudo nettop -l 1 -P -n -J bytes_in,bytes_out')")
    print("  → Python 方案已成功验证: nettop 可提供 per-process bytes_in/bytes_out")
}


// ---- 主函数 ----

print("""
╔══════════════════════════════════════════════════════════╗
║  libproc 进程网络流量 API 可行性预研                      ║
║  日期: \(ISO8601DateFormatter().string(from: Date()))
╚══════════════════════════════════════════════════════════╝
""")

let args = CommandLine.arguments
let givenPid: Int32? = args.count > 1 ? Int32(args[1]) : nil

let pids = findTargetPids(givenPid: givenPid)

if pids.isEmpty {
    print("⚠️  未找到目标进程。请指定 PID: ./research_libproc 1234")
    exit(1)
}

print("目标 PID: \(pids)")
for pid in pids {
    let name = getProcessName(pid: pid)
    let path = getProcessPath(pid: pid)
    print("  PID \(pid): \(name) → \(path)")
}

// 对所有目标 PID 运行测试
for pid in pids {
    testProcPidInfo(pid: pid)
    testProcPidRusage(pid: pid)
    testProcPidListFds(pid: pid)
}

testNettopAvailability()

print("""

════════════════════════════════════════════════════════════
预研结论:
  1. PROC_PIDTASKALLINFO → 只有 CPU 时间，无网络字节 ✓
  2. proc_pid_rusage      → 只有磁盘 IO，无网络字节 ✓
  3. PROC_PIDLISTFDS      → 可以枚举 socket fd ✓
  4. PROC_PIDFDSOCKETINFO → 需要进一步查 XNU 源码确认
                              soi_statistics 是否含收发字节

推荐方案:
  - 如果 soi_statistics 有字节数 → 可用 libproc（遍历 fd + 聚合）
  - 否则 → 使用 nettop 子进程（已验证可行）

下一步: 查阅 XNU 源码 <xnu/bsd/sys/proc_info.h> 中
         socket_fdinfo.soi_statistics 的定义
════════════════════════════════════════════════════════════
""")
