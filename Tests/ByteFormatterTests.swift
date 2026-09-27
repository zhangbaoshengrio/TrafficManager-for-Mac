import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - ByteFormatter 单元测试
// ============================================================

final class ByteFormatterTests: XCTestCase {
    func testZeroBytes() {
        XCTAssertEqual(ByteFormatter.string(bytes: 0), "0 B")
    }

    func testBytes() {
        XCTAssertEqual(ByteFormatter.string(bytes: 500), "500 B")
    }

    func testKilobytes() {
        let s = ByteFormatter.string(bytes: 1536)
        XCTAssertTrue(s.hasSuffix("KB"))
        XCTAssertTrue(s.hasPrefix("1.5"))
    }

    func testMegabytes() {
        let s = ByteFormatter.string(bytes: 2_500_000)
        XCTAssertTrue(s.contains("MB"))
    }

    func testGigabytes() {
        let s = ByteFormatter.string(bytes: 1_500_000_000)
        XCTAssertTrue(s.contains("GB"))
    }

    func testKilobyteExact() {
        XCTAssertEqual(ByteFormatter.string(bytes: 1024), "1.0 KB")
    }

    func testMegabyteExact() {
        XCTAssertEqual(ByteFormatter.string(bytes: 1_048_576), "1.0 MB")
    }

    func testRateSlow() {
        let s = ByteFormatter.rateString(bytesPerSecond: 50)
        XCTAssertEqual(s, "50 B/s")
    }

    func testRateKBs() {
        let s = ByteFormatter.rateString(bytesPerSecond: 2048)
        XCTAssertEqual(s, "2.0 KB/s")
    }

    func testRateMBs() {
        let s = ByteFormatter.rateString(bytesPerSecond: 3_145_728)
        XCTAssertEqual(s, "3.0 MB/s")
    }

    func testRateZero() {
        XCTAssertEqual(ByteFormatter.rateString(bytesPerSecond: 0), "0 B/s")
    }
}

// ============================================================
// MARK: - 数字 / 单位拆分
// ============================================================

/// 界面上要让单位待着不动，就得把它和数字分开摆。
/// 拆分结果必须和拼好的字符串完全一致 —— 否则两条路会各自漂移。
final class ByteFormatterPartsTests: XCTestCase {
    func testRatePartsSplitNumberFromUnit() {
        XCTAssertEqual(ByteFormatter.rateParts(bytesPerSecond: 0),
                       ByteFormatter.Parts(value: "0", unit: "B/s"))
        XCTAssertEqual(ByteFormatter.rateParts(bytesPerSecond: 1024 * 5.6),
                       ByteFormatter.Parts(value: "5.6", unit: "KB/s"))
    }

    func testBytePartsSplitNumberFromUnit() {
        XCTAssertEqual(ByteFormatter.parts(bytes: 0),
                       ByteFormatter.Parts(value: "0", unit: "B"))
        XCTAssertEqual(ByteFormatter.parts(bytes: 1024 * 1024 * 3 / 2),
                       ByteFormatter.Parts(value: "1.5", unit: "MB"))
    }

    /// 单位只有一个字母，进程行那种极窄的位置才放得下
    func testCompactRatePartsUseSingleLetterUnits() {
        XCTAssertEqual(ByteFormatter.compactRateParts(bytesPerSecond: 39).unit, "B")
        XCTAssertEqual(ByteFormatter.compactRateParts(bytesPerSecond: 5_300).unit, "K")
        XCTAssertEqual(ByteFormatter.compactRateParts(bytesPerSecond: 5_300_000).unit, "M")
    }

    /// 拼回去必须等于原来的整串写法，两条路不能漂移
    func testJoinedMatchesTheStringForms() {
        for exponent in 0...4 {
            for multiplier in [0.0, 1.0, 9.9, 99.0, 999.9] {
                let value = multiplier * pow(1024, Double(exponent))
                XCTAssertEqual(ByteFormatter.rateParts(bytesPerSecond: value).joined,
                               ByteFormatter.rateString(bytesPerSecond: value))
                XCTAssertEqual(ByteFormatter.parts(bytes: Int64(value)).joined,
                               ByteFormatter.string(bytes: Int64(value)))
            }
        }
    }

    /// 菜单栏那一串仍然恒定 5 字符 —— 它和面板共用分档规则，但不带基础档的单位字母
    func testMenuBarStringStaysFiveCharactersWide() {
        for exponent in 0...4 {
            for multiplier in [0.0, 1.0, 9.9, 99.0, 999.9] {
                let text = ByteFormatter.rateStringCompact(
                    bytesPerSecond: multiplier * pow(1024, Double(exponent)))
                XCTAssertEqual(text.count, 5, "「\(text)」不是 5 个字符")
            }
        }
    }
}
