import AppKit
import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - 菜单栏速率图
// ============================================================

final class MenuBarRateImageTests: XCTestCase {
    private func render(_ up: Double, _ down: Double, size: CGFloat = 9) -> NSImage {
        MenuBarRateImage.render(upBytesPerSecond: up, downBytesPerSecond: down, fontSize: size)
    }

    /// 图片必须正好是状态栏内容区的高度。
    /// SwiftUI 自己栅格化 label 时只给 16pt，两行就被裁成一行 —— 这条卡住那种回退。
    func testImageIsFullStatusBarHeight() {
        XCTAssertEqual(render(1_000, 2_000).size.height, NSStatusBar.system.thickness)
    }

    /// 必须是模板图，否则在深色菜单栏下会是一团黑
    func testImageIsTemplate() {
        XCTAssertTrue(render(1_000, 2_000).isTemplate)
    }

    /// 宽度恒定是硬要求：标签每秒重画，宽度一变整条菜单栏就会左右抖动
    func testWidthIsStableAcrossMagnitudes() {
        let widths = [0, 1, 999, 1_024, 999_999, 12_345_678, 9_876_543_210]
            .map { render(Double($0), Double($0)).size.width }
        XCTAssertEqual(Set(widths).count, 1, "不同数量级下宽度不一致: \(widths)")
    }

    func testWidthGrowsWithFontSize() {
        let small = render(1_000, 1_000, size: 7).size.width
        let large = render(1_000, 1_000, size: 11).size.width
        XCTAssertGreaterThan(large, small)
    }

    /// 字号超出范围要被夹住，而不是画出一张挤不下的图
    func testFontSizeIsClamped() {
        let tiny = render(1_000, 1_000, size: 1).size.width
        let atMin = render(1_000, 1_000, size: MenuBarRateImage.minFontSize).size.width
        XCTAssertEqual(tiny, atMin)

        let huge = render(1_000, 1_000, size: 99).size.width
        let atMax = render(1_000, 1_000, size: MenuBarRateImage.maxFontSize).size.width
        XCTAssertEqual(huge, atMax)
    }

    /// 图片非空 —— 纯透明说明文字压根没画上去
    func testImageHasVisibleContent() throws {
        let image = render(1_234, 1_234_567)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        var opaquePixels = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                opaquePixels += 1
            }
        }
        XCTAssertGreaterThan(opaquePixels, 20, "图片几乎全透明，文字没画上")
    }

    /// 上下两半都要有内容 —— 只有一半有像素就说明又被裁成一行了
    func testBothLinesAreDrawn() throws {
        let image = render(1_234, 1_234_567)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let half = rep.pixelsHigh / 2
        var top = 0, bottom = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                if y < half { top += 1 } else { bottom += 1 }
            }
        }
        XCTAssertGreaterThan(top, 10, "上半部分没有内容")
        XCTAssertGreaterThan(bottom, 10, "下半部分没有内容")
    }

    /// 图片里是文字，但对 VoiceOver 而言只是一张图 —— 必须有可读描述
    func testImageCarriesAccessibilityDescription() throws {
        let description = try XCTUnwrap(render(1_234, 1_234_567).accessibilityDescription)
        XCTAssertFalse(description.isEmpty)
        XCTAssertTrue(description.contains("/s"), "描述里应包含速率读数: \(description)")
    }

    /// 把各字号渲染成 PNG 落盘，便于人工核对外观
    func testExportSamplesForVisualReview() throws {
        guard let dir = ProcessInfo.processInfo.environment["MENUBAR_SAMPLE_DIR"] else {
            throw XCTSkip("未指定 MENUBAR_SAMPLE_DIR")
        }
        for size in stride(from: MenuBarRateImage.minFontSize, through: MenuBarRateImage.maxFontSize, by: 1) {
            let image = render(1_234, 1_234_567, size: size)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "\(dir)/menubar-\(Int(size))pt.png"))
        }
    }
}
