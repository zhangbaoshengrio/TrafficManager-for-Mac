import AppKit

/// 把上下行速率画成一张菜单栏图片。
///
/// ## 为什么要自己画，而不是直接给 MenuBarExtra 一个 SwiftUI 视图
///
/// SwiftUI 会把 `MenuBarExtra` 的 label 栅格化后塞进 `NSStatusBarButton.image`，
/// 并按菜单栏图标的惯例把高度压到 **16pt** —— 实测：
///
/// ```
/// NSView            frame=(0, 10.5, 60, 22)          ← 内容区确实有 22pt
///   NSStatusBarButton frame=(0, 0, 60, 22) fitting=(44, 16)   ← 只给了 16
/// ```
///
/// 两行 9pt 文字需要约 21pt，塞进 16pt 就被裁成一行 —— 这正是「只看得到一个箭头
/// 和一个数值」的原因。
///
/// 改成直接提供 `NSImage` 后，图片按原尺寸透传，按钮拿到完整 22pt：
///
/// ```
///   NSStatusBarButton frame=(0, 0, 57, 22) fitting=(41, 22)
///     image.size=(41, 22) template=true
/// ```
///
/// ## 宽度必须恒定
///
/// 标签每秒重画一次。只要图片宽度会变，整条菜单栏就会跟着左右抖动。
/// 所以宽度由「最宽可能字符串」一次算定，之后所有帧都用同一个宽度、右对齐绘制。
enum MenuBarRateImage {
    /// 状态栏内容区高度（实测 22pt）
    static var height: CGFloat { NSStatusBar.system.thickness }

    /// 允许的字号范围。上限受两行必须挤进 22pt 限制。
    static let minFontSize: CGFloat = 7
    static let maxFontSize: CGFloat = 11

    static func render(upBytesPerSecond up: Double,
                       downBytesPerSecond down: Double,
                       fontSize: CGFloat) -> NSImage {
        let size = max(minFontSize, min(maxFontSize, fontSize))
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        let lines = [text(up) + "↑", text(down) + "↓"]
        let width = fixedWidth(for: font)
        let total = NSSize(width: width, height: height)

        // 用 drawingHandler 而不是 lockFocus：前者与分辨率无关，
        // 系统需要什么倍率就以什么倍率重画一次，外接屏和内置屏都清晰。
        let image = NSImage(size: total, flipped: false) { _ in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black,   // 模板图会被系统重新着色，这里只提供形状
            ]
            let lineHeight = total.height / CGFloat(lines.count)
            for (index, line) in lines.enumerated() {
                let string = line as NSString
                let measured = string.size(withAttributes: attributes)
                // 右对齐；两行各自在自己那半格里垂直居中
                let x = total.width - measured.width - Self.horizontalInset
                let y = total.height - CGFloat(index + 1) * lineHeight
                    + (lineHeight - measured.height) / 2
                string.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            }
            return true
        }
        // 模板图 → 系统按菜单栏明暗、以及「强调色/反色」状态自动着色
        image.isTemplate = true
        // 图片里是文字，但对 VoiceOver 而言只是一张图 —— 得显式给出可读描述
        image.accessibilityDescription = L("menubar.accessibility", text(down), text(up))
        return image
    }

    // MARK: - Private

    private static let horizontalInset: CGFloat = 1

    private static func text(_ bytesPerSecond: Double) -> String {
        ByteFormatter.rateStringCompact(bytesPerSecond: bytesPerSecond)
            .trimmingCharacters(in: .whitespaces) + "/s"
    }

    /// 按字号缓存的固定宽度
    nonisolated(unsafe) private static var widthCache: [CGFloat: CGFloat] = [:]

    /// 取「最宽可能字符串」的宽度。
    ///
    /// 不手写模板串 —— 猜错了要么留白过多，要么被截断。直接把一组覆盖各数量级的
    /// 速率喂进真正的格式化器，量出实际最大宽度。格式化规则将来若变化，宽度会自动跟上。
    ///
    /// 两个箭头都量：↑ ↓ 未必与数字同属一个字族（可能回退），advance 不一定相同。
    private static func fixedWidth(for font: NSFont) -> CGFloat {
        if let cached = widthCache[font.pointSize] { return cached }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        var widest: CGFloat = 0
        for exponent in 0...4 {                      // B / K / M / G / T
            for multiplier in [1.0, 9.9, 10.0, 99.0, 999.0] {
                let value = multiplier * pow(1024, Double(exponent))
                for arrow in ["↑", "↓"] {
                    let candidate = text(value) + arrow as NSString
                    widest = max(widest, candidate.size(withAttributes: attributes).width)
                }
            }
        }

        let result = ceil(widest) + horizontalInset * 2
        widthCache[font.pointSize] = result
        return result
    }
}
