#!/usr/bin/env swift
//
// 生成 Resources/AppIcon.icns。
//
// 产物已提交进仓库，日常构建不需要跑这个脚本；只有想改图标时才重新生成：
//   swift Scripts/make-icon.swift
//
// 设计取舍：图标要在 16pt（菜单栏 / Finder 列表）下仍然可辨，
// 因此只用一个高对比度的上下箭头对，不放细节。
import AppKit
import Foundation

let canvas: CGFloat = 1024
// macOS Big Sur 之后的应用图标规范：圆角方形约占 824/1024，四周留透明边距
let plateInset: CGFloat = 100
let plateSize = canvas - plateInset * 2
let cornerRadius = plateSize * 0.2237

func makeImage() -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    ctx.setShouldAntialias(true)

    let plate = CGRect(x: plateInset, y: plateInset, width: plateSize, height: plateSize)
    let platePath = CGPath(roundedRect: plate,
                           cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                           transform: nil)

    // ── 底板渐变 ──
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let colors = [
        NSColor(srgbRed: 0.36, green: 0.62, blue: 0.98, alpha: 1).cgColor,  // 顶部亮蓝
        NSColor(srgbRed: 0.11, green: 0.31, blue: 0.72, alpha: 1).cgColor,  // 底部深蓝
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: plate.maxY),
                               end: CGPoint(x: 0, y: plate.minY),
                               options: [])
    }
    // 顶部高光：必须用渐变渐隐，直接铺半块矩形会在中线留一道硬边
    let highlight = [
        NSColor(white: 1, alpha: 0.18).cgColor,
        NSColor(white: 1, alpha: 0.0).cgColor,
    ] as CFArray
    if let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: highlight, locations: [0, 1]) {
        ctx.drawLinearGradient(gloss,
                               start: CGPoint(x: 0, y: plate.maxY),
                               end: CGPoint(x: 0, y: plate.minY + plate.height * 0.32),
                               options: [])
    }
    ctx.restoreGState()

    // ── 上下箭头对 ──
    // 下行（接收）实心白，上行（发送）半透明，形成主次关系
    let arrowHeight = plateSize * 0.46
    let shaftWidth = plateSize * 0.115
    let headWidth = plateSize * 0.30
    let headHeight = arrowHeight * 0.40
    let gap = plateSize * 0.09
    let centerY = plate.midY

    func arrow(centerX: CGFloat, pointingDown: Bool) -> CGPath {
        let path = CGMutablePath()
        let sign: CGFloat = pointingDown ? -1 : 1
        let tipY = centerY + sign * arrowHeight / 2
        let baseY = centerY - sign * arrowHeight / 2
        let shoulderY = tipY - sign * headHeight

        path.move(to: CGPoint(x: centerX, y: tipY))
        path.addLine(to: CGPoint(x: centerX - headWidth / 2, y: shoulderY))
        path.addLine(to: CGPoint(x: centerX - shaftWidth / 2, y: shoulderY))
        path.addLine(to: CGPoint(x: centerX - shaftWidth / 2, y: baseY))
        path.addLine(to: CGPoint(x: centerX + shaftWidth / 2, y: baseY))
        path.addLine(to: CGPoint(x: centerX + shaftWidth / 2, y: shoulderY))
        path.addLine(to: CGPoint(x: centerX + headWidth / 2, y: shoulderY))
        path.closeSubpath()
        return path
    }

    let offset = (headWidth + gap) / 2
    ctx.setShadow(offset: CGSize(width: 0, height: -canvas * 0.008),
                  blur: canvas * 0.02,
                  color: NSColor(white: 0, alpha: 0.25).cgColor)

    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(arrow(centerX: plate.midX - offset, pointingDown: true))
    ctx.fillPath()

    ctx.setFillColor(NSColor(white: 1, alpha: 0.62).cgColor)
    ctx.addPath(arrow(centerX: plate.midX + offset, pointingDown: false))
    ctx.fillPath()

    return image
}

// ── 导出 iconset → icns ──

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = makeImage()
// (边长, 文件名) —— iconutil 要求的完整集合
let variants: [(Int, String)] = [
    (16, "icon_16x16.png"),    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (px, name) in variants {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                from: NSRect(x: 0, y: 0, width: canvas, height: canvas),
                operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent(name))
}

let icns = resources.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败\n".data(using: .utf8)!)
    exit(1)
}
try FileManager.default.removeItem(at: iconset)
print("✓ \(icns.path)")
