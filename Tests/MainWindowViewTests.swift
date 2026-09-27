import XCTest
@testable import TrafficMonitor

/// `MainWindowView.rangeLabel`——不依赖视图状态或渲染，直接构造输入断言
/// 输出。天级选择（Last 7/30 days 等点一天）显示单个日期；小时级选择
/// （Today/Yesterday 点一个小时）显示 "HH:mm–HH:mm"。
final class MainWindowViewPureLogicTests: XCTestCase {
    @MainActor
    func testRangeLabelShowsSingleDateForDayLevelRange() {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date()).timeIntervalSince1970
        let range: ClosedRange<TimeInterval> = dayStart ... (dayStart + 86_400)
        let label = MainWindowView.rangeLabel(for: range)
        XCTAssertFalse(label.contains(":"), "天级 range 不该出现 HH:mm 冒号格式：\(label)")
    }

    @MainActor
    func testRangeLabelShowsHourRangeForHourLevelRange() {
        let hourStart = (Date().timeIntervalSince1970 / 3_600).rounded(.down) * 3_600
        let range: ClosedRange<TimeInterval> = hourStart ... (hourStart + 3_600)
        let label = MainWindowView.rangeLabel(for: range)
        XCTAssertTrue(label.contains("–"), "小时级 range 应该是 \"HH:mm–HH:mm\" 带范围符的格式：\(label)")
        XCTAssertTrue(label.contains(":"), "小时级 range 应该包含 HH:mm 冒号格式：\(label)")
    }
}
