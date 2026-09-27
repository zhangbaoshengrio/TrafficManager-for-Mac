import XCTest
@testable import TrafficMonitor

// ============================================================
// MARK: - 字符串表完整性
// ============================================================

/// 直接读源码目录里的 .strings 做静态校验。
/// 这类问题（漏翻、键写错）只在运行到那个界面时才暴露，靠测试卡住最划算。
final class StringTableTests: XCTestCase {
    /// 由测试文件位置反推仓库根目录，不依赖运行时工作目录
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // Tests/LocalizationTests.swift
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // 仓库根
    }

    private static func table(_ language: String) throws -> [String: String] {
        let url = repoRoot
            .appendingPathComponent("Sources/Resources/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: String])
    }

    func testBothLanguagesDefineTheSameKeys() throws {
        let en = try Self.table("en")
        let zh = try Self.table("zh-Hans")
        // 不用 XCTAssertEqual 比两个集合 —— 失败时它会把两份完整键表都打出来，
        // 几千字符里根本找不到差在哪。只报差集。
        let onlyEnglish = Set(en.keys).subtracting(zh.keys).sorted()
        let onlyChinese = Set(zh.keys).subtracting(en.keys).sorted()
        XCTAssertTrue(onlyEnglish.isEmpty, "中文表缺少: \(onlyEnglish)")
        XCTAssertTrue(onlyChinese.isEmpty, "英文表缺少: \(onlyChinese)")
    }

    func testNoEmptyTranslations() throws {
        for language in ["en", "zh-Hans"] {
            for (key, value) in try Self.table(language) {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(language) 的 \(key) 是空串")
            }
        }
    }

    /// 占位符数量必须一致，否则 String(format:) 会读到越界参数
    func testFormatSpecifiersMatchAcrossLanguages() throws {
        let en = try Self.table("en")
        let zh = try Self.table("zh-Hans")
        let pattern = try NSRegularExpression(pattern: "%(?:\\d+\\$)?[@dfs]")
        func count(_ s: String) -> Int {
            pattern.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
        }
        for (key, value) in en {
            XCTAssertEqual(count(value), count(zh[key] ?? ""),
                           "\(key) 的占位符数量不一致: en=\(value) / zh=\(zh[key] ?? "")")
        }
    }

    /// 源码里 L("…") 用到的键必须都在表里 —— 拼错的键在运行时只会显示键名本身
    func testEveryKeyUsedInSourceExists() throws {
        let defined = Set(try Self.table("en").keys)
        let sources = Self.repoRoot.appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #"\bL\(\s*"([^"]+)""#)

        var used = Set<String>()
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                used.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }

        XCTAssertFalse(used.isEmpty, "没有扫描到任何 L(\"…\") 调用，正则可能失效了")
        XCTAssertTrue(used.subtracting(defined).isEmpty,
                      "源码用到但表里没有的键: \(used.subtracting(defined).sorted())")
    }
}

// ============================================================
// MARK: - 运行时查表
// ============================================================

final class LocalizationRuntimeTests: XCTestCase {
    func testResourceBundleShipsBothLanguages() {
        // .process 会把 zh-Hans.lproj 小写成 zh-hans.lproj，之后再也匹配不上；
        // 这条断言就是用来卡住那种回退的
        for language in L10n.available {
            XCTAssertNotNil(Bundle.module.path(forResource: language, ofType: "lproj"),
                            "资源包里缺 \(language).lproj（大小写是否被 .process 改写？）")
        }
    }

    func testKnownKeyResolvesToRealText() {
        let text = L("toolbar.start")
        XCTAssertNotEqual(text, "toolbar.start", "查表失败会原样返回键名")
        XCTAssertFalse(text.isEmpty)
    }

    /// 缺失的键返回键名本身，比返回空串更容易发现
    func testUnknownKeyFallsBackToKeyItself() {
        let key = "definitely.not.a.real.key.\(UUID().uuidString)"
        XCTAssertEqual(L(key), key)
    }

    func testFormattedLookupSubstitutesArguments() {
        let text = L("settings.days", 30)
        XCTAssertTrue(text.contains("30"), "占位符没有被替换: \(text)")
        XCTAssertFalse(text.contains("%"), "格式串残留: \(text)")
    }

    func testEffectiveLanguageIsOneOfAvailable() {
        XCTAssertTrue(L10n.available.contains(L10n.effective))
    }

    /// 时间范围的 rawValue 必须与界面语言无关，否则换语言会读不出旧偏好
    @MainActor
    func testTimeRangeRawValuesAreLanguageNeutral() {
        for range in DashboardViewModel.TimeRange.allCases {
            XCTAssertTrue(range.rawValue.allSatisfy(\.isASCII),
                          "\(range.rawValue) 含非 ASCII，不适合做持久化标识")
        }
    }

    @MainActor
    func testChartStyleRawValuesAreLanguageNeutral() {
        for style in ChartStyle.allCases {
            XCTAssertTrue(style.rawValue.allSatisfy(\.isASCII),
                          "\(style.rawValue) 含非 ASCII，不适合做持久化标识")
        }
    }
}
